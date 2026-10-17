export const List = ({ items }) => (
  <ul>
    <li>
      <li>{items[0]}</li>
    </li>
    <Item.Row key="a" />
    <>
      fragment text
    </>
  </ul>
);
